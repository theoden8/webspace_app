import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show splitProxyAddress;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// The Tor (external) switch of the Experimental group and, while it is on,
/// the SOCKS address of the tor it names (TOR-025).
class ExternalTorTiles extends StatefulWidget {
  const ExternalTorTiles({super.key, this.onTorChanged});

  /// After the switch moved Tor to the other runtime, for a screen that
  /// names the Tor route elsewhere.
  final VoidCallback? onTorChanged;

  @override
  State<ExternalTorTiles> createState() => _ExternalTorTilesState();
}

class _ExternalTorTilesState extends State<ExternalTorTiles> {
  bool _switch = ExperimentalFeaturesService.instance
      .switchOn(ExperimentalFeature.externalTor);
  String _address = ExternalTorSettings.address;

  Future<void> _setSwitch(bool value) async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.externalTor, value);
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
          title: loc.appSettingsExperimentalExternalTor,
          hint: loc.appSettingsExperimentalExternalTorHint,
          control: Toggle(_switch, _setSwitch),
        ),
        if (_switch)
          SettingTile(
            leading: const Icon(Icons.lan_outlined),
            title: loc.externalTorAddress,
            hint: loc.externalTorAddressHint,
            subtitle: _address,
            control: Trailing(const Icon(Icons.edit_outlined),
                onTap: _editAddress),
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

  String? _validate(AppLocalizations loc, String value) {
    if (value.isEmpty) return loc.appSettingsProxyAddressRequired;
    if (splitProxyAddress(value) == null) {
      return loc.appSettingsProxyFormatHostPort;
    }
    return null;
  }

  void _save(AppLocalizations loc) {
    final value = _controller.text.trim();
    final error = _validate(loc, value);
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
