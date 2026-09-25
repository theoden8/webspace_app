import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/web_view_model.dart';

/// What the user picked in [DispatchPickerSheet]; null when dismissed.
sealed class DispatchChoice {
  const DispatchChoice();
}

class DispatchChoiceOpen extends DispatchChoice {
  final WebViewModel site;

  /// Outbound picker only: write the pick back to the source (LIR-016).
  final bool remember;

  const DispatchChoiceOpen(this.site, {this.remember = false});
}

class DispatchChoiceBind extends DispatchChoice {
  final WebViewModel site;
  const DispatchChoiceBind(this.site);
}

class DispatchChoiceCreate extends DispatchChoice {
  const DispatchChoiceCreate();
}

/// Outbound picker's "Open without routing" (LIR-016).
class DispatchChoiceFallback extends DispatchChoice {
  const DispatchChoiceFallback();
}

/// LIR-010 dispatch picker: shown when the resolver does not deliver a
/// unique winner. Lists each resolver winner ("router default" rows), an
/// option to bind the URL's host to an existing site (mutates that site's
/// `domainClaims` via `claimsToAdoptHost`), and an option to create a new
/// site with the path stripped to `<scheme>://<host>[:port]/`.
///
/// With [outboundSourceName] set it is the outbound picker (LIR-016): the
/// winners, a remember checkbox naming the source, and "Open without
/// routing".
class DispatchPickerSheet extends StatefulWidget {
  final Uri url;
  final List<WebViewModel> winners;
  final List<WebViewModel> otherSites;
  final bool canBind;
  final bool canCreate;
  final String? outboundSourceName;

  /// Whether picking a site should claim the URL's domain for future routing
  /// (LIR-010 option 2) or merely open the link there (discussion #439,
  /// default). Drives only the row labels here; the actual claim/no-claim
  /// decision is applied by the host via `LinkIntentDispatchEngine.sendToSite`.
  final bool claimDomains;

  const DispatchPickerSheet({
    super.key,
    required this.url,
    required this.winners,
    required this.otherSites,
    required this.canBind,
    required this.canCreate,
    required this.claimDomains,
    this.outboundSourceName,
  });

  @override
  State<DispatchPickerSheet> createState() => _DispatchPickerSheetState();
}

class _DispatchPickerSheetState extends State<DispatchPickerSheet> {
  bool _bindMode = false;
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final host = widget.url.host;
    final urlText = widget.url.toString();
    final allSites = [...widget.winners, ...widget.otherSites];
    final rows = _bindMode ? _buildBindRows(allSites) : _buildPrimaryRows();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _bindMode && widget.claimDomains
                      ? loc.homeDispatchSendToWhichSite(host)
                      : loc.homeDispatchOpenHost(host),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                urlText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: rows,
                ),
              ),
              const SizedBox(height: 8),
              if (_bindMode)
                TextButton(
                  onPressed: () => setState(() => _bindMode = false),
                  child: Text(loc.homeBackAction),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(loc.commonCancel),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _siteFavicon(WebViewModel site) => SizedBox(
        width: 32,
        height: 32,
        child: UnifiedFaviconImage(
          url: site.initUrl,
          size: 32,
          proxy: site.outboundProxySettings,
          customIcon: site.customIconPng,
          persist: !site.isArchiveTier,
        ),
      );

  List<Widget> _buildPrimaryRows() {
    final loc = AppLocalizations.of(context);
    final rows = <Widget>[];
    for (final site in widget.winners) {
      final displayName = site.getDisplayName();
      rows.add(ListTile(
        leading: _siteFavicon(site),
        title: Text(loc.homeDispatchOpenInSite(displayName)),
        subtitle: Text(site.initUrl,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.of(context).pop(DispatchChoiceOpen(
          site,
          remember: widget.outboundSourceName != null && _remember,
        )),
      ));
    }
    final sourceName = widget.outboundSourceName;
    if (sourceName != null) {
      rows.add(CheckboxListTile(
        value: _remember,
        onChanged: (v) => setState(() => _remember = v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(loc.homeDispatchRememberForSource(sourceName)),
      ));
      rows.add(ListTile(
        leading: const SizedBox(
            width: 32, height: 32, child: Icon(Icons.link_off)),
        title: Text(loc.homeDispatchOpenWithoutRouting),
        onTap: () =>
            Navigator.of(context).pop(const DispatchChoiceFallback()),
      ));
    }
    if (widget.canBind &&
        (widget.winners.isNotEmpty || widget.otherSites.isNotEmpty)) {
      rows.add(ListTile(
        leading: const SizedBox(
            width: 32, height: 32, child: Icon(Icons.link)),
        title: Text(widget.claimDomains
            ? loc.homeDispatchSendToSite(widget.url.host)
            : loc.homeDispatchOpenHostInSite(widget.url.host)),
        subtitle:
            widget.claimDomains ? Text(loc.homeDispatchPickExistingSite) : null,
        onTap: () => setState(() => _bindMode = true),
      ));
    }
    if (widget.canCreate) {
      final strippedHome = LinkRoutingService.strippedHomeUrl(widget.url) ?? '';
      rows.add(ListTile(
        leading: SizedBox(
          width: 32,
          height: 32,
          child: UnifiedFaviconImage(
            url: LinkRoutingService.strippedHomeUrl(widget.url) ??
                widget.url.toString(),
            size: 32,
          ),
        ),
        title: Text(loc.homeDispatchCreateNewSite(widget.url.host)),
        subtitle: Text(
          strippedHome,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () =>
            Navigator.of(context).pop(const DispatchChoiceCreate()),
      ));
    }
    return rows;
  }

  List<Widget> _buildBindRows(List<WebViewModel> sites) {
    final loc = AppLocalizations.of(context);
    if (sites.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(loc.homeDispatchNoExistingSites),
        ),
      ];
    }
    return sites
        .map((s) => ListTile(
              leading: _siteFavicon(s),
              title: Text(s.getDisplayName()),
              subtitle: Text(s.initUrl,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () =>
                  Navigator.of(context).pop(DispatchChoiceBind(s)),
            ))
        .toList(growable: false);
  }
}
