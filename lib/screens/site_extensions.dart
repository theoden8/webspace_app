import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_grants_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// Why a site's extensions cannot be switched, as its plan says (WEBEXT-009),
/// or null when they can.
Lock? siteExtensionsLock(ExtensionAttach plan) => switch (plan) {
  AttachExtensions() => null,
  NoExtensions(:final reason) => switch (reason) {
    NoExtensionsReason.archive => const ArchiveLock(),
    NoExtensionsReason.kiosk => const _KioskLock(),
    NoExtensionsReason.notOffered || NoExtensionsReason.noneEnabled => null,
  },
};

final class _KioskLock extends Lock {
  const _KioskLock() : super.because(null);

  @override
  String reason(AppLocalizations loc) => loc.siteExtensionsKioskLocked;
}

/// How many extensions a site's webviews load, by its plan.
int siteExtensionsOn(ExtensionAttach plan) => switch (plan) {
  AttachExtensions(:final loads) => loads.length,
  NoExtensions() => 0,
};

/// A site's Settings > Extensions (WEBEXT-004): a switch per imported
/// extension, each switched on only after the user has seen what it gets on
/// this site.
class SiteExtensionsScreen extends StatefulWidget {
  const SiteExtensionsScreen({
    super.key,
    required this.site,
    required this.onChanged,
  });

  final WebViewModel site;

  /// Fired after a switch changes, so the site's next webview takes it.
  final VoidCallback onChanged;

  @override
  State<SiteExtensionsScreen> createState() => _SiteExtensionsScreenState();
}

class _SiteExtensionsScreenState extends State<SiteExtensionsScreen> {
  final _guard = ReentryGuard();

  Future<void> _set(WebExtensionEntry entry, {required bool on}) async {
    await _guard.run(() async {
      final site = widget.site;
      if (on && !await _consent(entry)) return;
      if (!mounted) return;
      setState(() {
        site.enabledWebExtensions = on
            ? {...site.enabledWebExtensions, entry.id}
            : {
                for (final id in site.enabledWebExtensions)
                  if (id != entry.id) id,
              };
      });
      widget.onChanged();
    });
  }

  /// What [entry] gets on this site, as its webviews would grant it.
  Future<bool> _consent(WebExtensionEntry entry) {
    final loc = AppLocalizations.of(context);
    final grants = planExtensionGrants(
      entry,
      claims: widget.site.effectiveDomainClaims,
    );
    final patterns = grants.matchPatterns.toList()..sort();
    final permissions = grants.permissions.toList()..sort();
    return confirm(
      context,
      title: loc.siteExtensionsConsentTitle(entry.name),
      body: [
        patterns.isEmpty
            ? loc.siteExtensionsConsentReachesNothing
            : loc.siteExtensionsConsentReaches(patterns.join(', ')),
        permissions.isEmpty
            ? loc.siteExtensionsConsentNoPermissions
            : loc.siteExtensionsConsentPermissions(permissions.join(', ')),
      ].join('\n\n'),
      confirmLabel: loc.siteExtensionsSwitchOn,
      destructive: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsExtensions)),
      body: ValueListenableBuilder<List<InstalledExtension>>(
        valueListenable: WebExtensionLibrary.instance.installed,
        builder: (context, installed, _) {
          final lock = siteExtensionsLock(widget.site.extensionPlan);
          return ListView(
            children: [
              if (installed.isEmpty)
                ListTile(title: Text(loc.siteExtensionsEmpty)),
              for (final (:entry, folder: _) in installed)
                SettingTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: entry.name,
                  hint: null,
                  subtitle: loc.extensionsVersion(entry.version),
                  control: Toggle(
                    lock == null &&
                        widget.site.enabledWebExtensions.contains(entry.id),
                    onChanged: (on) => unawaited(_set(entry, on: on)),
                  ),
                  lock: lock,
                ),
            ],
          );
        },
      ),
    );
  }
}
