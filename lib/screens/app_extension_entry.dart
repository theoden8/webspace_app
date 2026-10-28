import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/screens/app_extensions.dart'
    show PackageRefusalLabel, ReleaseProblemLabel;
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/theme/design_tokens.dart';
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
  bool _updating = false;

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

  /// Downloads [entry]'s update and installs it, once the user accepts
  /// what it asks for beyond the installed version (WEBEXT-018).
  Future<void> _update(WebExtensionEntry entry) async {
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final messenger = ScaffoldMessenger.of(context);
      setState(() => _updating = true);
      try {
        final ExtensionPackage package;
        switch (await _library.prepareUpdate(entry.id)) {
          case UpdateUnreachable(:final reason):
            messenger.toast(loc.extensionsLinkUnreachable(reason));
            return;
          case UpdateNoRelease(:final why):
            messenger.toast(loc.extensionsLinkNoRelease(why.label(loc)));
            return;
          case UpdateNotAPackage(:final why):
            messenger.toast(loc.extensionsRefused(why.label(loc)));
            return;
          case UpdateReady(package: final ready, :final asks):
            if (!mounted) return;
            setState(() => _updating = false);
            if (asks case AsksMore(:final permissions, :final hosts)
                when !await _acceptMore(
                  entry,
                  permissions: permissions,
                  hosts: hosts,
                )) {
              return;
            }
            package = ready;
        }
        final updated = await _library.install(entry.id, package: package);
        messenger.toast(loc.extensionsUpdated(updated.name, updated.version));
      } on IOException catch (e) {
        messenger.toast(loc.extensionsImportFailed('$e'));
      } finally {
        if (mounted) setState(() => _updating = false);
      }
    });
  }

  /// What an update asks for beyond the installed version, which every
  /// site that runs it would get (WEBEXT-018).
  Future<bool> _acceptMore(
    WebExtensionEntry entry, {
    required Set<String> permissions,
    required Set<String> hosts,
  }) {
    final loc = AppLocalizations.of(context);
    return confirm(
      context,
      title: loc.extensionsUpdateAsksTitle(entry.name),
      body: [
        loc.extensionsUpdateAsksBody,
        if (permissions.isNotEmpty)
          loc.extensionsAsks((permissions.toList()..sort()).join(', ')),
        if (hosts.isNotEmpty)
          loc.extensionsReaches((hosts.toList()..sort()).join(', ')),
      ].join('\n\n'),
      confirmLabel: loc.extensionsUpdate,
      destructive: false,
    );
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
              if (entry.source case final source?)
                SettingTile(
                  leading: const Icon(Icons.link),
                  title: loc.extensionsSource,
                  hint: null,
                  subtitle: switch (entry.checkedAt) {
                    final at? => loc.extensionsSourceChecked(
                      source.label,
                      MaterialLocalizations.of(
                        context,
                      ).formatMediumDate(at.toLocal()),
                    ),
                    null => source.label,
                  },
                ),
              if (entry.latest case final latest?)
                SettingTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: loc.extensionsUpdateTo(latest),
                  hint: null,
                  subtitle: loc.extensionsVersion(entry.version),
                  control: Trailing(
                    _updating
                        ? const SizedBox.square(
                            dimension: IconSizes.action,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined),
                    onTap: _updating ? null : () => unawaited(_update(entry)),
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
