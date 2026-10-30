import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_grants_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/toast.dart';

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
  Localized reason(AppLocalizations loc) => loc.siteExtensionsKioskLocked;
}

/// How many extensions a site's webviews load, by its plan.
int siteExtensionsOn(ExtensionAttach plan) => switch (plan) {
  AttachExtensions(:final loads) => loads.length,
  NoExtensions() => 0,
};

/// A site's Settings > Extensions (WEBEXT-004): a switch per imported
/// extension that follows the extension's default until the site sets its
/// own, each switched on only after the user has seen what it gets on this
/// site, and the pages of those it runs (WEBEXT-008).
class SiteExtensionsScreen extends StatefulWidget {
  const SiteExtensionsScreen({
    super.key,
    required this.site,
    required this.isolation,
    required this.onChanged,
  });

  final WebViewModel site;
  final Isolation isolation;

  /// Fired after a switch changes, so the site's next webview takes it.
  final VoidCallback onChanged;

  @override
  State<SiteExtensionsScreen> createState() => _SiteExtensionsScreenState();
}

class _SiteExtensionsScreenState extends State<SiteExtensionsScreen> {
  final _guard = ReentryGuard();

  /// Whether the site runs [entry]: its own choice, else the extension's
  /// default (WEBEXT-004).
  bool _runs(WebExtensionEntry entry) =>
      widget.site.webExtensionChoices[entry.id] ?? entry.everySite;

  Future<void> _choose(
    WebExtensionEntry entry, {
    required Scoped<bool> choice,
  }) async {
    await _guard.run(() async {
      final site = widget.site;
      if (choice.resolve(entry.everySite) &&
          !_runs(entry) &&
          !await _consent(entry)) {
        return;
      }
      if (!mounted) return;
      setState(() {
        site.webExtensionChoices = {
          for (final MapEntry(:key, :value) in site.webExtensionChoices.entries)
            if (key != entry.id) key: value,
          if (choice case Own(:final value)) entry.id: value,
        };
      });
      widget.onChanged();
    });
  }

  Future<void> _open(
    ExtensionPage page, {
    required WebExtensionEntry entry,
    required ExtensionHome home,
  }) async {
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await WebExtensionLibrary.instance.open(
      page,
      extension: entry.id,
      home: home,
    )) {
      messenger.toast(loc.siteExtensionsPageFailed(entry.name));
    }
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
      body: Localized.joined([
        patterns.isEmpty
            ? loc.siteExtensionsConsentReachesNothing
            : loc.siteExtensionsConsentReaches(patterns.join(', ')),
        permissions.isEmpty
            ? loc.siteExtensionsConsentNoPermissions
            : loc.siteExtensionsConsentPermissions(permissions.join(', ')),
      ], by: Joined.paragraphs),
      confirmLabel: loc.siteExtensionsSwitchOn,
      destructive: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final library = WebExtensionLibrary.instance;
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsExtensions)),
      body: ListenableBuilder(
        listenable: Listenable.merge([library.installed, library.reports]),
        builder: (context, _) {
          final installed = library.installed.value;
          final lock = siteExtensionsLock(widget.site.extensionPlan);
          final home = widget.site.extensionHome(widget.isolation);
          Set<WebExtensionId> offering(ExtensionPage page) => {
            if (home != null)
              for (final entry in library.offering(page, home: home)) entry.id,
          };
          final options = offering(ExtensionPage.options);
          final actions = offering(ExtensionPage.action);
          return ListView(
            children: [
              if (installed.isEmpty)
                ListTile(title: Text(loc.siteExtensionsEmpty)),
              for (final (:entry, folder: _) in installed) ...[
                SettingTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: Localized.verbatim(entry.name),
                  hint: null,
                  control: ScopedToggle(
                    value: lock == null && _runs(entry),
                    choice: Scoped.fromStored(
                      widget.site.webExtensionChoices[entry.id],
                    ),
                    source: FollowSource.extensionDefault,
                    onChoice: (choice) =>
                        unawaited(_choose(entry, choice: choice)),
                  ),
                  lock: lock,
                ),
                if (home != null &&
                    (options.contains(entry.id) || actions.contains(entry.id)))
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: Spacing.xl,
                      end: Spacing.lg,
                    ),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.start,
                      spacing: Spacing.sm,
                      children: [
                        if (options.contains(entry.id))
                          TextButton.icon(
                            icon: const Icon(Icons.settings_outlined),
                            label: Text(loc.siteExtensionsSettings),
                            onPressed: () => unawaited(_open(
                              ExtensionPage.options,
                              entry: entry,
                              home: home,
                            )),
                          ),
                        if (actions.contains(entry.id))
                          TextButton.icon(
                            icon: const Icon(Icons.open_in_new),
                            label: Text(loc.siteExtensionsOpen),
                            onPressed: () => unawaited(_open(
                              ExtensionPage.action,
                              entry: entry,
                              home: home,
                            )),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
