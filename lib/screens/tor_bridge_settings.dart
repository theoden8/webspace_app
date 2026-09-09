// Bridge configuration: the screen a user reaches when Tor cannot connect
// because the network is blocking it (TOR-016).
//
// Three ways in, deliberately, because the private one must not be the
// hardest: paste a line obtained elsewhere, fetch from the Tor Project over
// Moat, or pick snowflake and configure nothing. The Moat route is disclosed
// rather than silent — that request goes direct and tells the local network
// you are asking for bridges (LEAK-010).
//
// Editing does not restart Tor. Bridges are read only at bootstrap, so an
// edit while Tor is up is inert until a restart; the screen says so and
// offers the restart rather than performing one behind the user's back,
// which would drop every site's circuits because a text field changed.

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_moat_client.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';

/// Message for a rejected paste. Kept next to the parse result so the screen
/// never has to say a generic "invalid bridge" — a half-copied line has a
/// specific missing half, and that is what the user needs told.
String bridgeParseErrorMessage(AppLocalizations loc, TorBridgeParseError e) =>
    switch (e) {
      TorBridgeParseError.empty => loc.torBridgeErrorEmpty,
      TorBridgeParseError.unknownTransport => loc.torBridgeErrorTransport,
      TorBridgeParseError.malformedAddress => loc.torBridgeErrorAddress,
      TorBridgeParseError.missingCertificate => loc.torBridgeErrorCert,
    };

/// Message for a failed Moat exchange.
String moatErrorMessage(AppLocalizations loc, MoatErrorKind kind) =>
    switch (kind) {
      // Not "the service is down": on a censored network this is the
      // expected outcome, and the useful advice is the other route in.
      MoatErrorKind.unreachable => loc.torMoatErrorUnreachable,
      MoatErrorKind.malformed => loc.torMoatErrorMalformed,
      MoatErrorKind.noBridges => loc.torMoatErrorNoBridges,
      // A rejected captcha is handled by re-prompting, never surfaced here.
      MoatErrorKind.wrongSolution => loc.torMoatErrorMalformed,
    };

class TorBridgeSettingsScreen extends StatefulWidget {
  const TorBridgeSettingsScreen({
    super.key,
    this.storage,
    this.moatClientFactory,
  });

  /// Injected in tests. Production uses the real keystore.
  final TorBridgeSecureStorage? storage;

  /// Injected in tests so the Moat exchange can be driven without network.
  final MoatClient Function()? moatClientFactory;

  @override
  State<TorBridgeSettingsScreen> createState() =>
      _TorBridgeSettingsScreenState();
}

class _TorBridgeSettingsScreenState extends State<TorBridgeSettingsScreen> {
  late final TorBridgeSecureStorage _storage =
      widget.storage ?? TorBridgeSecureStorage();
  final _pasteController = TextEditingController();

  TorBridgeConfig _config = const TorBridgeConfig();
  bool _loading = true;
  bool _busy = false;
  bool _restartNeeded = false;
  String? _pasteError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final loaded = await _storage.load();
    if (!mounted) return;
    setState(() {
      _config = loaded;
      _loading = false;
    });
  }

  /// Persist, then hand the configuration to the engine.
  ///
  /// Storage first: if the write fails there is nothing to tell tor about,
  /// and reporting success on a configuration that did not survive a restart
  /// would be a lie the user only discovers on the next launch.
  Future<void> _commit(TorBridgeConfig next) async {
    setState(() => _busy = true);
    final saved = await _storage.save(next);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _busy = false;
        _message = null;
      });
      return;
    }
    final needsRestart = TorService.instance.setBridges(next);
    setState(() {
      _config = next;
      _busy = false;
      _restartNeeded = _restartNeeded || needsRestart;
    });
  }

  Future<void> _addPasted() async {
    final result = parseTorBridgeLine(_pasteController.text);
    final loc = AppLocalizations.of(context);
    if (!result.isOk) {
      setState(() => _pasteError = bridgeParseErrorMessage(loc, result.error!));
      return;
    }
    final line = result.line!;
    // Adding a line for a transport that is not selected would silently do
    // nothing at bootstrap, since torBridgeOptions only emits lines matching
    // the selected transport. Follow the line rather than drop it.
    final next = _config.copyWith(
      transport: line.transport,
      lines: [..._config.lines, line],
    );
    _pasteController.clear();
    setState(() => _pasteError = null);
    await _commit(next);
  }

  Future<void> _remove(TorBridgeLine line) async {
    await _commit(_config.copyWith(
      lines: _config.lines.where((l) => l != line).toList(),
    ));
  }

  Future<void> _fetchFromMoat() async {
    final loc = AppLocalizations.of(context);
    final client = widget.moatClientFactory?.call() ?? MoatClient();
    setState(() {
      _busy = true;
      _message = loc.torBridgesFetching;
    });

    try {
      var attempt = await client.obtainBridges(_config.transport);

      if (attempt is MoatCaptchaRequired) {
        final solution = await _askCaptcha(attempt.challenge);
        if (solution == null) {
          // Cancelled: leave the configuration untouched rather than
          // committing a half-finished fetch.
          if (mounted) {
            setState(() {
              _busy = false;
              _message = null;
            });
          }
          return;
        }
        attempt = MoatBridgesObtained(
          await client.submitSolution(attempt.challenge, solution),
        );
      }

      final lines = (attempt as MoatBridgesObtained).lines;
      if (!mounted) return;
      setState(() => _message = null);
      await _commit(_config.copyWith(
        enabled: true,
        transport: lines.first.transport,
        lines: [..._config.lines, ...lines],
      ));
      if (mounted) {
        setState(() => _message = loc.torBridgesAdded(lines.length));
      }
    } on MoatException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = moatErrorMessage(loc, e.kind);
      });
    }
  }

  Future<String?> _askCaptcha(MoatChallenge challenge) async {
    final loc = AppLocalizations.of(context);
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(loc.torBridgesCaptchaTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.memory(challenge.imageBytes),
              const SizedBox(height: Spacing.md),
              Text(loc.torBridgesCaptchaHelp,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: Spacing.sm),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: loc.torBridgesCaptchaAnswer,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(loc.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(loc.commonOk),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _restartTor() async {
    setState(() => _busy = true);
    await TorService.instance.restart();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _restartNeeded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.torBridgesTitle),
        actions: [
          HintButton(
            title: loc.torBridgesTitle,
            description: loc.torBridgesHint,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  title: Text(loc.torBridgesEnable),
                  value: _config.enabled,
                  onChanged: _busy
                      ? null
                      : (v) => _commit(_config.copyWith(enabled: v)),
                ),
                ListTile(
                  title: Text(loc.torBridgesTransport),
                  trailing: DropdownButton<TorTransport>(
                    value: _config.transport,
                    onChanged: _busy
                        ? null
                        : (v) => v == null
                            ? null
                            : _commit(_config.copyWith(transport: v)),
                    items: [
                      for (final t in TorTransport.values)
                        DropdownMenuItem(value: t, child: Text(t.wireName)),
                    ],
                  ),
                ),
                if (_restartNeeded)
                  _notice(theme, loc.torBridgesRestartNeeded,
                      action: TextButton(
                        onPressed: _busy ? null : _restartTor,
                        child: Text(loc.torBridgesRestartNow),
                      )),
                const Divider(),
                _linesSection(loc, theme),
                const Divider(),
                _fetchSection(loc, theme),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.all(Spacing.lg),
                    child: Text(_message!, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
    );
  }

  Widget _notice(ThemeData theme, String text, {Widget? action}) => Container(
        color: theme.colorScheme.secondaryContainer,
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg, vertical: Spacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer)),
            ),
            ?action,
          ],
        ),
      );

  Widget _linesSection(AppLocalizations loc, ThemeData theme) {
    final lines = _config.lines
        .where((l) => l.transport == _config.transport)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Spacing.lg, Spacing.md, Spacing.lg, Spacing.xs),
          child:
              Text(loc.torBridgesLinesHeading, style: theme.textTheme.labelLarge),
        ),
        if (lines.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: Text(
              // Snowflake carries its own rendezvous defaults, so an empty
              // list is correct there rather than a missing step.
              _config.transport.worksWithoutBridgeLine
                  ? loc.torBridgesSnowflakeNeedsNone
                  : loc.torBridgesNoLines,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final line in lines)
          ListTile(
            dense: true,
            title: Text(line.raw,
                style: theme.textTheme.bodySmall, maxLines: 3),
            trailing: IconButton(
              tooltip: loc.torBridgesRemove,
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : () => _remove(line),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _pasteController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: loc.torBridgesPasteLabel,
                    errorText: _pasteError,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    if (!_busy) _addPasted();
                  },
                ),
              ),
              const SizedBox(width: Spacing.sm),
              TextButton(
                onPressed: _busy ? null : _addPasted,
                child: Text(loc.torBridgesAdd),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fetchSection(AppLocalizations loc, ThemeData theme) => Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LEAK-010: the exposure is stated before the button, not after
            // it and not in a hint the user has to open.
            Text(
              loc.torBridgesFetchExposure,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.sm),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _fetchFromMoat,
              icon: const Icon(Icons.download_outlined),
              label: Text(loc.torBridgesFetch),
            ),
          ],
        ),
      );
}
