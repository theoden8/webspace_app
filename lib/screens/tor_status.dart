import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/external_tor_control_tiles.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/tor_status_card.dart';

/// Tor as one runtime shared by the whole app (TOR-004): what state it is
/// in, what is using it, and the settings that apply to all of it at once.
class TorStatusScreen extends StatefulWidget {
  const TorStatusScreen({super.key, this.sites = const {}});

  /// The sites that may be listed as using Tor, each with the country it
  /// pins: they need not agree, since only the loaded ones must (TOR-014).
  final Map<SiteId, TorSiteLabel> sites;

  @override
  State<TorStatusScreen> createState() => _TorStatusScreenState();
}

class _TorStatusScreenState extends State<TorStatusScreen> {
  StreamSubscription<TorStatus>? _sub;

  /// Whether an external tor takes an exit country, and so whether a site's
  /// is shown, moves with its control channel, not with the status (TOR-026).
  StreamSubscription<ExternalTorControlState>? _controlSub;

  @override
  void initState() {
    super.initState();
    // Holders, the exit pin and bridges carry no stream of their own; each
    // changes around a status transition, so the status is the refresh.
    _sub = TorService.instance.statusStream.listen((_) {
      if (mounted) setState(() {});
    });
    _controlSub = TorService.instance.externalControlStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_controlSub?.cancel());
    super.dispose();
  }

  String _exitCountry(AppLocalizations loc, {required String? nodes}) {
    if (nodes == null || nodes.isEmpty) return loc.siteSettingsTorExitCountryAny;
    final code = RegExp(r'^\{([a-zA-Z]{2})\}$').firstMatch(nodes)?.group(1);
    return torExitCountryFor(code)?.label ?? code?.toUpperCase() ?? nodes;
  }

  bool get _isolationDiffers => switch (TorService.instance.externalControl) {
        TorControlAttached(:final gaps) => gaps.any((gap) => switch (gap) {
              TorSharedCircuits() ||
              TorPerDestinationHost() ||
              TorPerDestinationPort() ||
              TorSocksFlagsUnknown() =>
                true,
              TorOwnExits() || TorLogsAddresses() => false,
            }),
        _ => false,
      };

  /// Where an attached external tor sends a site that pins no country: its
  /// own `ExitNodes`, not any country (TOR-026).
  String? get _ownExits => switch (TorService.instance.externalControl) {
        TorControlAttached(:final gaps) =>
          gaps.whereType<TorOwnExits>().firstOrNull?.nodes,
        _ => null,
      };

  Localized _bridges(AppLocalizations loc) {
    final config = TorService.instance.bridges;
    if (!config.enabled || !config.isUsable) return loc.torStateBridgesOff;
    return Localized.verbatim(config.transport.wireName);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final using = summarizeTorHolders(TorService.instance.holders,
        sites: widget.sites);
    final external = TorService.instance.isExternal;
    final exitsChosen = TorService.instance.hasControlPort;
    final ownExits = _ownExits;
    final externalAddress = ExternalTorSettings.address;

    return Scaffold(
      appBar: AppBar(title: Text(loc.torStatusTitle)),
      body: ListView(
        children: [
          const TorStatusCard(),
          const Divider(),
          SettingsSection(loc.torStateUsedBy),
          if (using.isEmpty)
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: Text(loc.torStateNothing),
            ),
          if (using.appWide)
            ListTile(
              leading: const Icon(Icons.public),
              title: Text(loc.torStateAppWide),
              subtitle: Text(loc.torStateAppWideSubtitle),
            ),
          for (final site in using.sites)
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(site.name),
              subtitle: exitsChosen
                  ? Text(loc.torStateSiteExitCountry(
                      _exitCountry(loc, nodes: site.exitNodes ?? ownExits)))
                  : null,
            ),
          if (using.otherSites > 0)
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: Text(loc.torStateOtherSites(using.otherSites)),
            ),
          const Divider(),
          // An external tor keeps its bridges to itself (TOR-025).
          if (external) ...[
            SettingTile(
              leading: const Icon(Icons.lan_outlined),
              title: loc.externalTor,
              hint: loc.externalTorHint,
              subtitle: Localized.verbatim(externalAddress),
            ),
            if (externalTorControlRunsHere) const ExternalTorControlTiles(),
          ],
          if (!external) ...[
            SettingTile(
              leading: const Icon(Icons.alt_route),
              title: loc.torBridgesTitle,
              hint: loc.torBridgesHint,
              subtitle: _bridges(loc),
              control: Opens(() async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TorBridgeSettingsScreen(),
                  ),
                );
                if (mounted) setState(() {});
              }),
            ),
          ],
          SettingTile(
            leading: const Icon(Icons.call_split),
            title: loc.torStateCircuits,
            hint: loc.torStateCircuitsHint,
            // Not claimed for an external tor the app read otherwise; the
            // rows above say how it splits them (TOR-026).
            subtitle: _isolationDiffers ? null : loc.torStateCircuitsPerSite,
          ),
        ],
      ),
    );
  }
}
