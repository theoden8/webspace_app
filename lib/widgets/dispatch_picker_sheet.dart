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
              TextButton(
                onPressed: _bindMode
                    ? () => setState(() => _bindMode = false)
                    : () => Navigator.of(context).pop(),
                child: Text(_bindMode ? loc.homeBackAction : loc.commonCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A row for [site] that picks [choice].
  Widget _siteRow(WebViewModel site,
          {required String title, required DispatchChoice choice}) =>
      ListTile(
        leading: SizedBox(
          width: 32,
          height: 32,
          child: UnifiedFaviconImage.site(site, size: 32),
        ),
        title: Text(title),
        subtitle:
            Text(site.initUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.of(context).pop(choice),
      );

  List<Widget> _buildPrimaryRows() {
    final loc = AppLocalizations.of(context);
    final sourceName = widget.outboundSourceName;
    final strippedHome = LinkRoutingService.strippedHomeUrl(widget.url);
    return [
      for (final site in widget.winners)
        _siteRow(
          site,
          title: loc.homeDispatchOpenInSite(site.getDisplayName()),
          choice: DispatchChoiceOpen(site, remember: sourceName != null && _remember),
        ),
      if (sourceName != null) ...[
        CheckboxListTile(
          value: _remember,
          onChanged: (v) => setState(() => _remember = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(loc.homeDispatchRememberForSource(sourceName)),
        ),
        ListTile(
          leading: const SizedBox(
              width: 32, height: 32, child: Icon(Icons.link_off)),
          title: Text(loc.homeDispatchOpenWithoutRouting),
          onTap: () =>
              Navigator.of(context).pop(const DispatchChoiceFallback()),
        ),
      ],
      if (widget.canBind &&
          (widget.winners.isNotEmpty || widget.otherSites.isNotEmpty))
        ListTile(
          leading: const SizedBox(
              width: 32, height: 32, child: Icon(Icons.link)),
          title: Text(widget.claimDomains
              ? loc.homeDispatchSendToSite(widget.url.host)
              : loc.homeDispatchOpenHostInSite(widget.url.host)),
          subtitle: widget.claimDomains
              ? Text(loc.homeDispatchPickExistingSite)
              : null,
          onTap: () => setState(() => _bindMode = true),
        ),
      if (widget.canCreate)
        ListTile(
          leading: SizedBox(
            width: 32,
            height: 32,
            child: UnifiedFaviconImage(
              url: strippedHome ?? widget.url.toString(),
              size: 32,
            ),
          ),
          title: Text(loc.homeDispatchCreateNewSite(widget.url.host)),
          subtitle: Text(
            strippedHome ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () =>
              Navigator.of(context).pop(const DispatchChoiceCreate()),
        ),
    ];
  }

  List<Widget> _buildBindRows(List<WebViewModel> sites) => sites.isEmpty
      ? [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child:
                Text(AppLocalizations.of(context).homeDispatchNoExistingSites),
          ),
        ]
      : [
          for (final s in sites)
            _siteRow(s,
                title: s.getDisplayName(), choice: DispatchChoiceBind(s)),
        ];
}
