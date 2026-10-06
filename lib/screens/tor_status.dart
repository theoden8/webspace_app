import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/tor_status_card.dart';

/// Tor as one runtime shared by the whole app (TOR-004): what state it is
/// in, what is using it, and the settings that apply to all of it at once.
class TorStatusScreen extends StatefulWidget {
  const TorStatusScreen({super.key, this.siteNames = const {}});

  /// siteId to display name, for the sites listed as using Tor.
  final Map<String, String> siteNames;

  @override
  State<TorStatusScreen> createState() => _TorStatusScreenState();
}

class _TorStatusScreenState extends State<TorStatusScreen> {
  StreamSubscription<TorStatus>? _sub;

  @override
  void initState() {
    super.initState();
    // Holders, the exit pin and bridges carry no stream of their own; each
    // changes around a status transition, so the status is the refresh.
    _sub = TorService.instance.statusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _exitCountry(AppLocalizations loc) {
    final nodes = TorService.instance.exitNodes;
    if (nodes == null || nodes.isEmpty) return loc.siteSettingsTorExitCountryAny;
    final code = RegExp(r'^\{([a-zA-Z]{2})\}$').firstMatch(nodes)?.group(1);
    return torExitCountryFor(code)?.label ?? code?.toUpperCase() ?? nodes;
  }

  String _bridges(AppLocalizations loc) {
    final config = TorService.instance.bridges;
    if (!config.enabled || !config.isUsable) return loc.torStateBridgesOff;
    return config.transport.wireName;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final using =
        summarizeTorHolders(TorService.instance.holders, widget.siteNames);
    final external = TorService.instance.isExternal;
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
          for (final name in using.sites)
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(name),
            ),
          if (using.otherSites > 0)
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: Text(loc.torStateOtherSites(using.otherSites)),
            ),
          const Divider(),
          // An external tor keeps its exits and bridges to itself: the app
          // reaches it over SOCKS alone (TOR-025).
          if (external)
            SettingTile(
              leading: const Icon(Icons.lan_outlined),
              title: loc.appSettingsExperimentalExternalTor,
              hint: loc.appSettingsExperimentalExternalTorHint,
              subtitle: externalAddress,
            ),
          if (!external)
            SettingTile(
              leading: const Icon(Icons.flag_outlined),
              title: loc.siteSettingsTorExitCountry,
              hint: loc.torStateExitCountryHint,
              subtitle: _exitCountry(loc),
            ),
          if (!external)
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
          SettingTile(
            leading: const Icon(Icons.call_split),
            title: loc.torStateCircuits,
            hint: loc.torStateCircuitsHint,
            subtitle: loc.torStateCircuitsPerSite,
          ),
        ],
      ),
    );
  }
}
