import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show splitProxyAddress;
import 'package:webspace/services/proxy_test_service.dart'
    show kDefaultProxyTestTarget;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/widgets/external_tor_control_tiles.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// The Tor (external) switch of App Settings' Network screen and, while it
/// is on, the SOCKS address of the tor it names (TOR-025), its control port
/// (TOR-026) and a connection test through it.
class ExternalTorTiles extends StatefulWidget {
  const ExternalTorTiles(
      {super.key, required this.offersTest, this.onTorChanged});

  /// Whether the section has its own connection test: not where a proxy
  /// form on the same screen already tests the app-global Tor route.
  final bool offersTest;

  /// After the switch moved Tor to the other runtime, for a screen that
  /// names the Tor route elsewhere.
  final VoidCallback? onTorChanged;

  @override
  State<ExternalTorTiles> createState() => _ExternalTorTilesState();
}

class _ExternalTorTilesState extends State<ExternalTorTiles> {
  bool _switch = AppPref.externalTor.value;
  String _address = ExternalTorSettings.address;

  Future<void> _setSwitch(bool value) async {
    await AppPref.externalTor.set(value);
    if (!mounted) return;
    setState(() => _switch = value);
    await TorService.instance.runtimeChoiceChanged();
    widget.onTorChanged?.call();
  }

  Future<void> _editAddress() async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => ExternalTorAddressDialog(initial: _address),
    );
    if (next == null || next == _address) return;
    await ExternalTorSettings.setAddress(next);
    if (!mounted) return;
    setState(() => _address = next);
    await TorService.instance.externalAddressChanged();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingTile(
          leading: const Icon(Icons.security_outlined),
          title: loc.externalTor,
          hint: loc.externalTorHint,
          control: Toggle(value: _switch, onChanged: _setSwitch),
        ),
        if (_switch)
          SettingTile(
            leading: const Icon(Icons.lan_outlined),
            title: loc.externalTorAddress,
            hint: loc.externalTorAddressHint,
            subtitle: Localized.verbatim(_address),
            control: Trailing(const Icon(Icons.edit_outlined),
                onTap: _editAddress),
          ),
        if (_switch && externalTorControlRunsHere)
          const ExternalTorControlTiles(),
        // The app-global Tor route, so nothing has to be set to Tor first.
        // Keyed by the address: an answer about the last one is stale.
        if (_switch && widget.offersTest)
          ProxyTestTile(
            key: ValueKey(_address),
            settings: () => UserProxySettings(type: ProxyType.TOR),
            target: kDefaultProxyTestTarget,
          ),
      ],
    );
  }
}

/// Asks for the external tor's `host:port`. Pops the trimmed address, or
/// null when cancelled.
class ExternalTorAddressDialog extends StatefulWidget {
  const ExternalTorAddressDialog({super.key, required this.initial});

  final String initial;

  @override
  State<ExternalTorAddressDialog> createState() =>
      _ExternalTorAddressDialogState();
}

class _ExternalTorAddressDialogState extends State<ExternalTorAddressDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(AppLocalizations loc, {required String value}) {
    if (value.isEmpty) return loc.appSettingsProxyAddressRequired;
    if (splitProxyAddress(value) == null) {
      return loc.appSettingsProxyFormatHostPort;
    }
    return null;
  }

  void _save(AppLocalizations loc) {
    final value = _controller.text.trim();
    final error = _validate(loc, value: value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.externalTorAddress),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          hintText: AppPref.externalTorAddress.fallback,
          errorText: _error,
        ),
        onSubmitted: (_) => _save(loc),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.commonCancel),
        ),
        TextButton(
          onPressed: () => _save(loc),
          child: Text(loc.commonSave),
        ),
      ],
    );
  }
}
