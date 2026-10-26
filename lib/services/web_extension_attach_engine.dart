/// What a site's webviews get of the extension library (WEBEXT-016):
/// nothing and why, or which extensions load with what grants. Decided once
/// per site from the site and the app, so the site's own webview, its nested
/// screens and its popups get the same answer.
library;

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
  /// This system's WebKit cannot load extensions.
  unsupported,

  /// Developer mode or the Web extensions switch is off.
  experimentOff,

  /// The site is in an archive.
  archive,

  /// The site runs as a kiosk.
  kiosk,

  /// The site switched none on.
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

/// One extension a site loads, and what it may reach there.
typedef ExtensionLoad = ({WebExtensionId id, ExtensionGrants grants});

/// What decides a site's extensions.
typedef ExtensionAttachInputs = ({
  bool supported,
  bool experimentOn,
  bool archived,
  bool kiosk,
  bool incognito,
  Set<WebExtensionId> enabled,
  List<WebExtensionEntry> library,
  List<DomainClaim> claims,
});

ExtensionAttach planExtensionAttach(ExtensionAttachInputs inputs) {
  if (!inputs.supported) {
    return const NoExtensions(NoExtensionsReason.unsupported);
  }
  if (!inputs.experimentOn) {
    return const NoExtensions(NoExtensionsReason.experimentOff);
  }
  if (inputs.archived) return const NoExtensions(NoExtensionsReason.archive);
  if (inputs.kiosk) return const NoExtensions(NoExtensionsReason.kiosk);
  final loads = [
    for (final entry in inputs.library)
      if (inputs.enabled.contains(entry.id))
        (
          id: entry.id,
          grants: planExtensionGrants(entry, claims: inputs.claims),
        ),
  ];
  if (loads.isEmpty) return const NoExtensions(NoExtensionsReason.noneEnabled);
  return AttachExtensions(persistent: !inputs.incognito, loads: loads);
}
