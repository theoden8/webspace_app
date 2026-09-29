import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show resolveEffectiveProxy;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/saved_proxies.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart'
    show savedProxyLabel;
import 'package:webspace/widgets/proxy_status_indicator.dart';

/// Where the page's cookies, logins and site data live.
enum SiteContainerKind {
  /// The site's own native container, apart from every other site.
  own,

  /// A temporary store, thrown away when the webview closes (incognito on
  /// iOS, macOS and Linux).
  ephemeral,

  /// The one store every site shares, with cookies swapped per site (the
  /// legacy engine).
  shared,
}

/// What the site info sheet shows about the page on screen.
class SiteInfo {
  const SiteInfo({
    required this.siteName,
    required this.pageUrl,
    required this.containerId,
    required this.incognito,
    this.proxy,
    this.siteId,
  });

  /// The site the page runs as: its settings, identity and container.
  final String siteName;
  final String pageUrl;

  /// The native container the webview binds, from `containerIdFor`; null when
  /// it binds none.
  final String? containerId;
  final bool incognito;

  /// The site's proxy as configured, or null where the platform binds no
  /// proxy to a site (PROXY-006), in which case the sheet says nothing
  /// about the route.
  final UserProxySettings? proxy;

  /// The Tor stream-isolation tag, so a Tor route is checked on the site's
  /// own circuit.
  final String? siteId;

  SiteContainerKind get containerKind {
    if (containerId != null) return SiteContainerKind.own;
    if (incognito) return SiteContainerKind.ephemeral;
    return SiteContainerKind.shared;
  }
}

Future<void> showSiteInfoSheet(BuildContext context, SiteInfo info) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SiteInfoSheet(info: info),
    );

/// Which of the user's sites the page on screen runs as, and which container
/// holds its data. A nested screen opened by a link runs as the site that
/// opened it, or as the site outbound routing picked, and nothing else on
/// screen says which.
class SiteInfoSheet extends StatelessWidget {
  const SiteInfoSheet({super.key, required this.info});

  final SiteInfo info;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final container = switch (info.containerKind) {
      SiteContainerKind.own => loc.siteInfoContainerOwn,
      SiteContainerKind.ephemeral => loc.siteInfoContainerEphemeral,
      SiteContainerKind.shared => loc.siteInfoContainerShared,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(loc.siteInfoTitle, style: theme.textTheme.titleLarge),
            ),
            _InfoRow(
              icon: Icons.public,
              label: loc.siteInfoSite,
              value: info.siteName,
            ),
            _InfoRow(
              icon: Icons.link,
              label: loc.siteInfoPage,
              value: info.pageUrl,
            ),
            _InfoRow(
              icon: Icons.inventory_2_outlined,
              label: loc.siteInfoContainer,
              value: container,
              detail: info.containerId,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                loc.siteInfoContainerExplanation,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            if (info.proxy != null) ...[
              const SizedBox(height: 8),
              _connection(loc, info.proxy!, info.siteId),
            ],
          ],
        ),
      ),
    );
  }
}

/// Which route the site's traffic takes, and whether that route answers
/// (PROXY-030).
Widget _connection(
  AppLocalizations loc,
  UserProxySettings configured,
  String? siteId,
) {
  final route = resolveEffectiveProxy(configured, siteId: siteId);
  // Data, not copy (LOC-002): a type name and an address.
  final address = switch (route.type) {
    ProxyType.DEFAULT || ProxyType.SAVED => null,
    ProxyType.TOR => route.type.name,
    _ => '${route.type.name} ${route.address ?? ''}'.trim(),
  };
  final String value;
  if (route.type == ProxyType.DEFAULT) {
    value = loc.siteInfoConnectionDirect;
  } else if (configured.type == ProxyType.DEFAULT) {
    value = loc.networkSummaryAppProxy;
  } else if (configured.type == ProxyType.SAVED) {
    final saved = SavedProxies.byId(configured.savedProxyId);
    value = saved == null ? loc.savedProxyMissing : savedProxyLabel(saved);
  } else {
    value = address ?? route.type.name;
  }
  return _InfoRow(
    icon: Icons.vpn_lock_outlined,
    label: loc.siteInfoConnection,
    value: value,
    detail: value == address ? null : address,
    status: route.type == ProxyType.DEFAULT
        ? null
        : ProxyStatusIndicator(proxy: route),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.status,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A technical identifier under the value, selectable so it can be matched
  /// against logs.
  final String? detail;

  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    return ListTile(
      leading: Icon(icon, color: muted),
      title: Text(label,
          style: theme.textTheme.labelMedium?.copyWith(color: muted)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(value, style: theme.textTheme.bodyLarge),
          if (detail != null)
            SelectableText(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                fontFamily: 'monospace',
              ),
            ),
          if (status != null) status!,
        ],
      ),
    );
  }
}
