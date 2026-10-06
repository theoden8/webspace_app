import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/site_search_list_tile.dart';

/// How the site tab strip is presented, as one mutually-exclusive choice:
/// 0 = hidden, 1 = always pinned, 2 = revealed on demand by the floating
/// button. The button and the strip are the same feature (the button reveals
/// the strip), so they are one control, not two independent toggles.
int tabStripMode({required bool showTabStrip, required bool tabBarButton}) {
  if (tabBarButton) return 2;
  if (showTabStrip) return 1;
  return 0;
}

/// Whether the Default search row and the site search list are offered: web
/// search ships with Site tabs (LIR-029, TAB-012), read on every build so
/// flipping either switch takes effect at once.
bool webSearchSettingsOffered() =>
    DeveloperModeService.instance.enabled &&
    ExperimentalFeaturesService.instance.switchOn(ExperimentalFeature.siteTabs);

/// How the app hosts sites: the tab strip, full screen, the back gesture and
/// where shared links and searches go.
class AppBehaviourScreen extends StatefulWidget {
  const AppBehaviourScreen({
    super.key,
    required this.showTabStrip,
    required this.onShowTabStripChanged,
    required this.tabStripInFullscreen,
    required this.onTabStripInFullscreenChanged,
    required this.tabBarButton,
    required this.onTabBarButtonChanged,
    required this.tabMaxWidth,
    required this.onTabMaxWidthChanged,
    required this.fullscreenOnShortcut,
    required this.onFullscreenOnShortcutChanged,
    required this.backOpensMenu,
    required this.onBackOpensMenuChanged,
    required this.linkHandlingEnabled,
    required this.onOpenLinkHandlingSettings,
    this.webSearchSites = const [],
  });

  final bool showTabStrip;
  final ValueChanged<bool> onShowTabStripChanged;
  final bool tabStripInFullscreen;
  final ValueChanged<bool> onTabStripInFullscreenChanged;
  final bool tabBarButton;
  final ValueChanged<bool> onTabBarButtonChanged;
  final int tabMaxWidth;
  final ValueChanged<int> onTabMaxWidthChanged;
  final bool fullscreenOnShortcut;
  final ValueChanged<bool> onFullscreenOnShortcutChanged;

  /// NAV-009: back gesture opens the drawer where a site has no page left to
  /// go back to (and leaves the app on the press after that). Off by default.
  final bool backOpensMenu;
  final ValueChanged<bool> onBackOpensMenuChanged;

  /// LIR-008: entry into the routing overview screen. The wrapping page
  /// handles persistence.
  final bool linkHandlingEnabled;
  final VoidCallback onOpenLinkHandlingSettings;

  /// The user's web search sites outside every archive (LIR-029), each with
  /// its container's colour, null on the legacy engine.
  final List<PickableSearchSite> webSearchSites;

  @override
  State<AppBehaviourScreen> createState() => _AppBehaviourScreenState();
}

class _AppBehaviourScreenState extends State<AppBehaviourScreen>
    with SettingsOpenGuard {
  late bool _showTabStrip = widget.showTabStrip;
  late bool _tabStripInFullscreen = widget.tabStripInFullscreen;
  late bool _tabBarButton = widget.tabBarButton;
  late double _tabMaxWidth = widget.tabMaxWidth.toDouble();
  late bool _fullscreenOnShortcut = widget.fullscreenOnShortcut;
  late bool _backOpensMenu = widget.backOpensMenu;
  String _webSearchDefault = '';

  @override
  void initState() {
    super.initState();
    _loadWebSearchDefault();
  }

  int get _tabStripMode =>
      tabStripMode(showTabStrip: _showTabStrip, tabBarButton: _tabBarButton);

  void _setTabStripMode(int mode) {
    setState(() {
      _showTabStrip = mode == 1;
      _tabBarButton = mode == 2;
      // "Keep in full screen" only applies to a pinned strip. Leaving it set
      // in button mode would pin the strip in full screen and hide the button
      // there; clear it whenever we leave the pinned mode.
      if (mode != 1) _tabStripInFullscreen = false;
    });
    widget.onShowTabStripChanged(_showTabStrip);
    widget.onTabBarButtonChanged(_tabBarButton);
    if (mode != 1) widget.onTabStripInFullscreenChanged(_tabStripInFullscreen);
  }

  /// Full-screen behavior of the *pinned* tab strip: 0 = hidden, 1 = always
  /// visible. Only shown when the strip is pinned; button mode reveals the
  /// strip in full screen on its own.
  int get _fullscreenTabStripMode => _tabStripInFullscreen ? 1 : 0;

  void _setFullscreenTabStripMode(int mode) {
    setState(() {
      _tabStripInFullscreen = mode == 1;
    });
    widget.onTabStripInFullscreenChanged(_tabStripInFullscreen);
  }

  /// Whether the tab strip can appear at all (pinned out of fullscreen, pinned
  /// in fullscreen, or revealed by the tab-bar button), so the width limit is
  /// meaningful.
  bool get _tabStripCanShow =>
      _showTabStrip || _tabStripInFullscreen || _tabBarButton;

  String? get _webSearchDefaultName {
    final site = widget.webSearchSites
        .where((s) => s.siteId == _webSearchDefault)
        .firstOrNull;
    if (site == null) return null;
    return searchSiteSummaryName(site.name, site.siteId,
        widget.webSearchSites.map((s) => s.name));
  }

  Future<void> _loadWebSearchDefault() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _webSearchDefault =
        readPrefAs<String>(prefs, kWebSearchDefaultSiteKey) ?? '');
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
        selected: _webSearchDefault,
        emptyText: loc.webSearchNoWebSites,
        cancelLabel: loc.commonCancel,
      ),
    );
    if (picked == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kWebSearchDefaultSiteKey, picked);
    if (!mounted) return;
    setState(() => _webSearchDefault = picked);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final backOpensMenuHint = hostIsAndroid
        ? '${loc.appSettingsBackOpensMenuHint} ${loc.appSettingsBackOpensMenuHintExit}'
        : loc.appSettingsBackOpensMenuHint;
    final backOpensMenuOffered = backAtHistoryStartConfigurable(
      isIOS: hostIsIOS,
      isMacOS: hostIsMacOS,
    );
    final tabWidthLabel = '${_tabMaxWidth.round()} px';
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsBehaviour)),
      body: ListView(
        children: [
          SettingsGroupHeader(loc.appSettingsGroupTabStrip),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: Text(loc.appSettingsSiteTabStrip)),
                      HintButton(
                        title: loc.appSettingsSiteTabStrip,
                        description: loc.appSettingsSiteTabStripSubtitle,
                      ),
                    ],
                  ),
                ),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment<int>(
                      value: 0,
                      icon: const Icon(Icons.visibility_off),
                      tooltip: loc.appSettingsFullscreenTabStripHidden,
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      icon: const Icon(Icons.visibility),
                      tooltip: loc.appSettingsFullscreenTabStripAlways,
                    ),
                    ButtonSegment<int>(
                      value: 2,
                      icon: const Icon(Icons.smart_button),
                      tooltip: loc.appSettingsFullscreenTabStripButton,
                    ),
                  ],
                  selected: {_tabStripMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      _setTabStripMode(selection.first),
                ),
              ],
            ),
          ),
          // Pinned mode only: whether the pinned strip stays visible in full
          // screen. Button mode reveals the strip in full screen on its own;
          // hidden mode has nothing to keep.
          if (_tabStripMode == 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(child: Text(loc.appSettingsFullscreenTabStrip)),
                  SegmentedButton<int>(
                    segments: [
                      ButtonSegment<int>(
                        value: 0,
                        icon: const Icon(Icons.visibility_off),
                        tooltip: loc.appSettingsFullscreenTabStripHidden,
                      ),
                      ButtonSegment<int>(
                        value: 1,
                        icon: const Icon(Icons.visibility),
                        tooltip: loc.appSettingsFullscreenTabStripAlways,
                      ),
                    ],
                    selected: {_fullscreenTabStripMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        _setFullscreenTabStripMode(selection.first),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: Text(loc.appSettingsTabMaxWidth)),
                      HintButton(
                        title: loc.appSettingsTabMaxWidth,
                        description: loc.appSettingsTabMaxWidthHint,
                      ),
                    ],
                  ),
                ),
                Text(tabWidthLabel),
              ],
            ),
          ),
          Slider(
            value: _tabMaxWidth,
            min: 80,
            max: 320,
            divisions: 24,
            label: tabWidthLabel,
            onChanged: _tabStripCanShow
                ? (value) {
                    setState(() {
                      _tabMaxWidth = value;
                    });
                  }
                : null,
            onChangeEnd: _tabStripCanShow
                ? (value) {
                    widget.onTabMaxWidthChanged(value.round());
                  }
                : null,
          ),
          SettingsGroupHeader(loc.appSettingsGroupOpening),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsFullscreenOnShortcut)),
                HintButton(
                  title: loc.appSettingsFullscreenOnShortcut,
                  description: loc.appSettingsFullscreenOnShortcutHint,
                ),
              ],
            ),
            value: _fullscreenOnShortcut,
            onChanged: (value) {
              setState(() {
                _fullscreenOnShortcut = value;
              });
              widget.onFullscreenOnShortcutChanged(value);
            },
          ),
          // Apple has no back gesture the app can act on (NAV-009), so the
          // setting is absent there rather than present and inert.
          if (backOpensMenuOffered)
            SwitchListTile(
              title: Row(
                children: [
                  Flexible(child: Text(loc.appSettingsBackOpensMenu)),
                  HintButton(
                    title: loc.appSettingsBackOpensMenu,
                    // The escalation to leaving the app is Android's alone
                    // (NAV-009), so the sentence describing it stays off every
                    // other platform.
                    description: backOpensMenuHint,
                  ),
                ],
              ),
              value: _backOpensMenu,
              onChanged: (value) {
                setState(() {
                  _backOpensMenu = value;
                });
                widget.onBackOpensMenuChanged(value);
              },
            ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(loc.appSettingsLinkHandling),
            subtitle: Text(widget.linkHandlingEnabled
                ? loc.appSettingsLinkHandlingOn
                : loc.appSettingsLinkHandlingOff),
            trailing: const Icon(Icons.chevron_right),
            // The opener pushes synchronously, so the route check in the
            // guard is what drops a second tap.
            onTap: () => guardedOpen(
                () async => widget.onOpenLinkHandlingSettings()),
          ),
          if (webSearchSettingsOffered()) ...[
            SettingsGroupHeader(loc.webSearchGroup),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: Row(
                children: [
                  Flexible(child: Text(loc.webSearchDefaultTitle)),
                  HintButton(
                    title: loc.webSearchDefaultTitle,
                    description: loc.webSearchDefaultHint,
                  ),
                ],
              ),
              subtitle: Text(_webSearchDefaultName ??
                  loc.appSettingsNotConfigured),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => guardedOpen(_pickWebSearchDefault),
            ),
            const SiteSearchListTile(formatCount: formatSettingsCount),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
