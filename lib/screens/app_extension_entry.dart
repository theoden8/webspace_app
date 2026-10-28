import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/toast.dart';

/// One imported extension: whether a site that sets no choice of its own
/// runs it (WEBEXT-004), what it asks for, what WebKit reported reading it
/// (WEBEXT-003), and its removal (WEBEXT-002).
class ExtensionEntryScreen extends StatefulWidget {
  const ExtensionEntryScreen({super.key, required this.id});

  final WebExtensionId id;

  @override
  State<ExtensionEntryScreen> createState() => _ExtensionEntryScreenState();
}

class _ExtensionEntryScreenState extends State<ExtensionEntryScreen> {
  final _guard = ReentryGuard();

  WebExtensionLibrary get _library => WebExtensionLibrary.instance;

  WebExtensionEntry? get _entry => [
    for (final (:entry, folder: _) in _library.installed.value)
      if (entry.id == widget.id) entry,
  ].firstOrNull;

  Future<void> _setEverySite(WebExtensionEntry entry, {required bool on}) async {
    await _guard.run(() async {
      if (on && !await _consentEverySite(entry)) return;
      await _library.setEverySite(entry.id, on: on);
    });
  }

  /// What every site that follows the default gets (WEBEXT-004).
  Future<bool> _consentEverySite(WebExtensionEntry entry) {
    final loc = AppLocalizations.of(context);
    return confirm(
      context,
      title: loc.extensionsEverySiteConsentTitle(entry.name),
      body: [..._asks(entry, loc: loc), loc.extensionsEverySiteConsentBody]
          .join('\n\n'),
      confirmLabel: loc.siteExtensionsSwitchOn,
      destructive: false,
    );
  }

  List<String> _asks(WebExtensionEntry entry, {required AppLocalizations loc}) {
    final permissions = entry.permissions.toList()..sort();
    final hosts = entry.hosts.toList()..sort();
    return [
      permissions.isEmpty
          ? loc.extensionsAsksNothing
          : loc.extensionsAsks(permissions.join(', ')),
      hosts.isEmpty
          ? loc.extensionsReachesNothing
          : loc.extensionsReaches(hosts.join(', ')),
    ];
  }

  Future<void> _remove(WebExtensionEntry entry) async {
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      if (!await confirm(
        context,
        title: loc.extensionsRemoveTitle(entry.name),
        body: loc.extensionsRemoveBody,
        confirmLabel: loc.commonRemove,
        destructive: true,
      )) {
        return;
      }
      await _library.remove(entry.id);
      messenger.toast(loc.extensionsRemoved(entry.name));
      navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_library.installed, _library.reports]),
      builder: (context, _) {
        final entry = _entry;
        if (entry == null) return const Scaffold();
        final problems =
            _library.reports.value[entry.id]?.problems ?? const <String>[];
        return Scaffold(
          appBar: AppBar(title: Text(entry.name)),
          body: ListView(
            children: [
              SettingTile(
                title: loc.extensionsEverySite,
                hint: loc.extensionsEverySiteHint,
                subtitle: loc.extensionsVersion(entry.version),
                control: Toggle(
                  entry.everySite,
                  onChanged: (on) => unawaited(_setEverySite(entry, on: on)),
                ),
              ),
              SettingsSection(loc.extensionsAsksSection),
              for (final line in _asks(entry, loc: loc))
                ListTile(title: Text(line)),
              if (problems.isNotEmpty) ...[
                SettingsSection(loc.extensionsProblemsSection),
                for (final problem in problems)
                  ListTile(
                    leading: const Icon(
                      Icons.warning_amber_outlined,
                      color: HintedTitle.missingDataColor,
                    ),
                    title: Text(problem),
                  ),
              ],
              const Divider(),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(loc.commonRemove),
                onTap: () => unawaited(_remove(entry)),
              ),
            ],
          ),
        );
      },
    );
  }
}
