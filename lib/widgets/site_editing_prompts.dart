import 'package:flutter/material.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_editing_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen;
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/suggested_sites_service.dart'
    as suggested_sites;
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart';

/// [SiteEditingPrompts] as the add-site screen and dialogs over the page that
/// owns [context]. The add-site screen also changes the theme and the
/// suggested sites, which [shell] holds and [applyTheme] applies.
class DialogSiteEditingPrompts implements SiteEditingPrompts {
  const DialogSiteEditingPrompts(
    this.context, {
    required this.shell,
    required this.applyTheme,
  });

  final BuildContext context;
  final ShellStore shell;
  final Future<void> Function(AppThemeSettings next) applyTheme;

  @override
  Future<Object?> addSite({String? initialUrl}) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => AddSiteScreen(
        themeMode: shell.theme.themeMode,
        onThemeModeChanged: (mode) =>
            applyTheme(shell.theme.copyWith(themeMode: mode)),
        suggestions: shell.suggestedSites,
        onSuggestionsChanged: (sites) {
          shell.suggestedSites = sites;
          suggested_sites.saveSuggestedSites(sites);
        },
        initialUrl: initialUrl,
      ),
    ),
  );

  /// The payload is authored by whoever printed the code, reaches us from any
  /// app or web page via the exported `webspace://` scheme, and can turn every
  /// protection off, point the site at a proxy, and name it anything.
  @override
  Future<bool> reviewQrSettings(Map<String, dynamic> qr) async {
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
      if (turnsOff('trackingProtectionEnabled'))
        loc.siteSettingsTrackingProtection,
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
      if (turnsOn('thirdPartyCookiesEnabled'))
        loc.siteSettingsThirdPartyCookies,
      if (turnsOn('notificationsEnabled')) loc.siteSettingsNotifications,
      if (turnsOn('backgroundAudioEnabled')) loc.siteSettingsBackgroundAudio,
      if (turnsOn('kioskMode')) loc.siteSettingsKioskMode,
      if (qr['locationMode'] is String &&
          qr['locationMode'] != LocationMode.off.name)
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

  @override
  Future<SiteEdit?> editSite(WebViewModel site) =>
      showEditSiteDialog(context, site: site);

  @override
  Future<bool> confirmDelete(WebViewModel site) async {
    final loc = AppLocalizations.of(context);
    final siteName = site.getDisplayName();
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}
