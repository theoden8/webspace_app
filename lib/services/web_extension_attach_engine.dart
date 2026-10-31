/// What a site's webviews get of the extension library (WEBEXT-016):
/// nothing and why, or which extensions load with what grants. Decided once
/// per site from the site and the app, so the site's own webview, its nested
/// screens and its popups get the same answer.
library;

import 'package:webspace/services/container_names.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/web_extension_grants_engine.dart';
import 'package:webspace/settings/web_extension.dart';

sealed class ExtensionAttach {
  const ExtensionAttach();
}

/// No extension runs, and why: the reason a site's Extensions row shows.
final class NoExtensions extends ExtensionAttach {
  const NoExtensions(this.reason);
  final NoExtensionsReason reason;
}

enum NoExtensionsReason {
  /// Not offered here: this system's WebKit cannot load extensions, or
  /// developer mode or the Web extensions switch is off.
  notOffered,

  /// The site is in an archive.
  archive,

  /// The site runs as a kiosk.
  kiosk,

  /// The site runs none: it switched none on, and follows no extension's
  /// default that is on.
  noneEnabled,
}

/// The extensions a site's webviews load.
final class AttachExtensions extends ExtensionAttach {
  const AttachExtensions({required this.persistent, required this.loads})
    : assert(loads.length > 0, 'an attach loads at least one extension');

  /// False for an incognito site: nothing its extensions store outlives
  /// the app.
  final bool persistent;
  final List<ExtensionLoad> loads;
}

/// One extension a site loads, from where, which version of its files
/// (an update loads them again), and what it may reach there.
typedef ExtensionLoad = ({
  WebExtensionId id,
  String folder,
  String revision,
  ExtensionGrants grants,
});

/// What decides a site's extensions.
typedef ExtensionAttachInputs = ({
  bool offered,
  bool archived,
  bool kiosk,
  bool incognito,
  // The site's own choices; an extension it has none for follows the
  // entry's default (WEBEXT-004).
  Map<WebExtensionId, bool> choices,
  // The extensions WebKit loads on this device (WEBEXT-003).
  List<InstalledExtension> library,
  List<DomainClaim> claims,
});

ExtensionAttach planExtensionAttach(ExtensionAttachInputs inputs) {
  if (!inputs.offered) return const NoExtensions(NoExtensionsReason.notOffered);
  if (inputs.archived) return const NoExtensions(NoExtensionsReason.archive);
  if (inputs.kiosk) return const NoExtensions(NoExtensionsReason.kiosk);
  final loads = [
    for (final (:entry, :folder) in inputs.library)
      if (inputs.choices[entry.id] ?? entry.everySite)
        (
          id: entry.id,
          folder: folder,
          revision: entry.version,
          grants: planExtensionGrants(entry, claims: inputs.claims),
        ),
  ];
  if (loads.isEmpty) return const NoExtensions(NoExtensionsReason.noneEnabled);
  return AttachExtensions(persistent: !inputs.incognito, loads: loads);
}

/// Where a site's extensions keep what they store, and so where their pages
/// open (WEBEXT-008): what the site loads, in the container its webviews
/// bind.
typedef ExtensionHome = ({AttachExtensions plan, ContainerName container});

/// [plan]'s home in [container], or null where its extensions keep nothing:
/// a site that loads none, an incognito site, a site with no container.
ExtensionHome? extensionHomeOf(
  ExtensionAttach plan, {
  required ContainerName? container,
}) {
  if (container == null) return null;
  return switch (plan) {
    final AttachExtensions attach when attach.persistent => (
      plan: attach,
      container: container,
    ),
    AttachExtensions() || NoExtensions() => null,
  };
}
