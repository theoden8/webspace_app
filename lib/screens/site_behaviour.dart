import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
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
    required this.blockAutoRedirects,
    required this.externalLinksInBrowser,
  });

  final bool alwaysOpenHome;
  final bool kioskMode;
  final bool fullscreenMode;
  final bool htmlCachingEnabled;
  final bool blockAutoRedirects;
  final bool externalLinksInBrowser;

  SiteBehaviourValues copyWith({
    bool? alwaysOpenHome,
    bool? kioskMode,
    bool? fullscreenMode,
    bool? htmlCachingEnabled,
    bool? blockAutoRedirects,
    bool? externalLinksInBrowser,
  }) =>
      SiteBehaviourValues(
        alwaysOpenHome: alwaysOpenHome ?? this.alwaysOpenHome,
        kioskMode: kioskMode ?? this.kioskMode,
        fullscreenMode: fullscreenMode ?? this.fullscreenMode,
        htmlCachingEnabled: htmlCachingEnabled ?? this.htmlCachingEnabled,
        blockAutoRedirects: blockAutoRedirects ?? this.blockAutoRedirects,
        externalLinksInBrowser:
            externalLinksInBrowser ?? this.externalLinksInBrowser,
      );

  /// Incognito drops the stored URL on every restart, so the site opens at its
  /// home page whatever this stores. Mirrors `WebViewModel.toJson`'s `dropUrl`,
  /// which is what actually decides it.
  bool effectiveAlwaysOpenHome(bool incognito) => incognito || alwaysOpenHome;
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
  /// reader looks for it (the external-links hint points at it by name).
  final Widget? domainClaims;

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

  Widget _htmlCaching(AppLocalizations loc) => _tile(
        title: loc.siteSettingsHtmlCaching,
        hintTitle: loc.siteSettingsHtmlCachingHintTitle,
        hint: loc.siteSettingsHtmlCachingHint,
        value: _values.htmlCachingEnabled,
        onChanged: (value) =>
            _update(_values.copyWith(htmlCachingEnabled: value)),
      );

  // --- Link handling -------------------------------------------------------

  Widget _blockAutoRedirects(AppLocalizations loc) => _tile(
        title: loc.siteSettingsBlockAutoRedirects,
        hintTitle: loc.siteSettingsBlockAutoRedirectsHintTitle,
        hint: loc.siteSettingsBlockAutoRedirectsHint,
        subtitle: loc.siteSettingsBlockAutoRedirectsSubtitle,
        value: _values.blockAutoRedirects,
        onChanged: (value) =>
            _update(_values.copyWith(blockAutoRedirects: value)),
      );

  Widget _externalLinks(AppLocalizations loc) => _tile(
        title: loc.siteSettingsExternalLinksInBrowser,
        hintTitle: loc.siteSettingsExternalLinksInBrowserHintTitle,
        hint: loc.siteSettingsExternalLinksInBrowserHint,
        value: _values.externalLinksInBrowser,
        onChanged: (value) =>
            _update(_values.copyWith(externalLinksInBrowser: value)),
      );

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
          _htmlCaching(loc),
          _groupHeader(loc.linkHandlingScreenTitle),
          _blockAutoRedirects(loc),
          _externalLinks(loc),
          if (widget.domainClaims != null) widget.domainClaims!,
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
