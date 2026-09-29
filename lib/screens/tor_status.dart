import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/tor_holders.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';
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

  Widget _groupHeader(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.lg, Spacing.lg, Spacing.lg, Spacing.xs),
        child: Text(
          title,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      );

  Widget _hinted(String title, String hint) => Row(
        children: [
          Flexible(child: Text(title)),
          HintButton(title: title, description: hint),
        ],
      );

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
    final theme = Theme.of(context);
    final using =
        summarizeTorHolders(TorService.instance.holders, widget.siteNames);

    return Scaffold(
      appBar: AppBar(title: Text(loc.torStatusTitle)),
      body: ListView(
        children: [
          const TorStatusCard(),
          const Divider(),
          _groupHeader(theme, loc.torStateUsedBy),
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
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: _hinted(
                loc.siteSettingsTorExitCountry, loc.torStateExitCountryHint),
            subtitle: Text(_exitCountry(loc)),
          ),
          ListTile(
            leading: const Icon(Icons.alt_route),
            title: _hinted(loc.torBridgesTitle, loc.torBridgesHint),
            subtitle: Text(_bridges(loc)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TorBridgeSettingsScreen(),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.call_split),
            title: _hinted(loc.torStateCircuits, loc.torStateCircuitsHint),
            subtitle: Text(loc.torStateCircuitsPerSite),
          ),
        ],
      ),
    );
  }
}
