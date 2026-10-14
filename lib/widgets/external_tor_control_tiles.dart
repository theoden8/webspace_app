import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/external_tor_control_password_storage.dart';
import 'package:webspace/services/external_tor_posture_engine.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// The external tor's control port row and, once the app is attached, how
/// that tor treats sites differently from the built-in one (TOR-026).
class ExternalTorControlTiles extends StatefulWidget {
  const ExternalTorControlTiles({super.key});

  @override
  State<ExternalTorControlTiles> createState() =>
      _ExternalTorControlTilesState();
}

class _ExternalTorControlTilesState extends State<ExternalTorControlTiles> {
  StreamSubscription<ExternalTorControlState>? _sub;
  String _endpoint = ExternalTorSettings.control;

  @override
  void initState() {
    super.initState();
    _sub = TorService.instance.externalControlStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _edit() async {
    final storage = ExternalTorControlPasswordStorage();
    final password = await storage.load() ?? '';
    if (!mounted) return;
    final next = await showDialog<({String endpoint, String password})>(
      context: context,
      builder: (_) => ExternalTorControlDialog(
          endpoint: _endpoint, password: password),
    );
    if (next == null) return;
    await storage.save(next.password);
    await ExternalTorSettings.setControl(next.endpoint);
    if (!mounted) return;
    setState(() => _endpoint = next.endpoint);
    await TorService.instance.externalAddressChanged();
  }

  String _summary(AppLocalizations loc,
      {required ExternalTorControlState state}) {
    if (_endpoint.isEmpty) return loc.externalTorControlNotSet;
    return switch (state) {
      TorControlIdle() || TorControlAsking() => _endpoint,
      TorControlAttached() => loc.externalTorControlConnected,
      TorControlNotAttached(:final refusal) => switch (refusal) {
          TorControlRefusal.unreachable => loc.externalTorControlUnreachable,
          TorControlRefusal.notTor => loc.externalTorControlNotTor,
          TorControlRefusal.needsPassword =>
            loc.externalTorControlNeedsPassword,
          TorControlRefusal.cookieUnreadable =>
            loc.externalTorControlCookieUnreadable,
          TorControlRefusal.refused => loc.externalTorControlRefused,
          TorControlRefusal.otherTor => loc.externalTorControlOtherTor,
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final state = TorService.instance.externalControl;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingTile(
          leading: const Icon(Icons.settings_ethernet),
          title: loc.externalTorControl,
          hint: loc.externalTorControlHint,
          subtitle: _summary(loc, state: state),
          missingData: state is TorControlNotAttached,
          control: Trailing(const Icon(Icons.edit_outlined), onTap: _edit),
        ),
        if (state is TorControlAttached && _endpoint.isNotEmpty)
          ...state.gaps.isEmpty
              ? [
                  SettingTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: loc.externalTorPostureSame,
                    hint: null,
                  ),
                ]
              : [for (final gap in state.gaps) _PostureGapTile(gap)],
      ],
    );
  }
}

class _PostureGapTile extends StatelessWidget {
  const _PostureGapTile(this.gap);

  final TorPostureGap gap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final (title, hint) = switch (gap) {
      TorSharedCircuits() => (
          loc.externalTorGapSharedCircuits,
          loc.externalTorGapSharedCircuitsHint
        ),
      TorPerDestinationHost() =>
        (loc.externalTorGapPerHost, loc.externalTorGapPerHostHint),
      TorPerDestinationPort() =>
        (loc.externalTorGapPerPort, loc.externalTorGapPerPortHint),
      TorOwnExits(:final nodes) =>
        (loc.externalTorGapOwnExits(nodes), loc.externalTorGapOwnExitsHint),
      TorLogsAddresses() =>
        (loc.externalTorGapLogs, loc.externalTorGapLogsHint),
      TorSocksFlagsUnknown() => (
          loc.externalTorGapUnknownFlags,
          loc.externalTorGapUnknownFlagsHint
        ),
    };
    return SettingTile(
      leading: const Icon(Icons.warning_amber_outlined,
          color: HintedTitle.missingDataColor),
      title: title,
      hint: hint,
    );
  }
}

/// Asks for the control endpoint and its password. Pops both trimmed, an
/// empty endpoint for none, or null when cancelled.
class ExternalTorControlDialog extends StatefulWidget {
  const ExternalTorControlDialog({
    super.key,
    required this.endpoint,
    required this.password,
  });

  final String endpoint;
  final String password;

  @override
  State<ExternalTorControlDialog> createState() =>
      _ExternalTorControlDialogState();
}

class _ExternalTorControlDialogState extends State<ExternalTorControlDialog> {
  late final TextEditingController _endpoint =
      TextEditingController(text: widget.endpoint);
  late final TextEditingController _password =
      TextEditingController(text: widget.password);
  String? _error;

  @override
  void dispose() {
    _endpoint.dispose();
    _password.dispose();
    super.dispose();
  }

  void _save(AppLocalizations loc) {
    final endpoint = _endpoint.text.trim();
    if (endpoint.isNotEmpty && TorControlEndpoint.parse(endpoint) == null) {
      setState(() => _error = loc.externalTorControlFormat);
      return;
    }
    Navigator.of(context).pop((endpoint: endpoint, password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.externalTorControl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _endpoint,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: loc.externalTorControlAddressLabel,
              hintText: externalTorControlExample,
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _save(loc),
          ),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: loc.externalTorControlPasswordLabel,
            ),
            onSubmitted: (_) => _save(loc),
          ),
        ],
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
